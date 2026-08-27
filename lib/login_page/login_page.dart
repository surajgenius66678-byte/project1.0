import'package:flutter/material.dart';

class LoginPage extends StatelessWidget{
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Material(
      
      child: Image(image: AssetImage("assets/image/login.png"),
      fit:BoxFit.cover ,),
    );
  }


}